import AVFAudio
import MeowverseCore
import os
import SwiftUI

/// The two room sound preferences, read by the player and switched in the 音乐音效 panel. The keys
/// are what earlier builds stored: renaming one would silently drop every user's choice.
enum RoomSoundKeys {
    static let music = "room.music"
    static let effects = "room.soundEffects"
}

/// Plays one of the room's soft button sounds (`RoomChime`). It stays silent when sound effects
/// are off or the room is not in front; RoomSounds supplies it to the room.
struct RoomChimeAction: Sendable {
    fileprivate let play: @MainActor @Sendable (RoomChime) -> Void

    @MainActor func callAsFunction(_ chime: RoomChime) { play(chime) }
}

extension EnvironmentValues {
    @Entry var roomChime = RoomChimeAction { _ in }
}

/// The room's few button sounds, on the same events as its haptics: a piece placed (from a photo
/// or the catalog), the cat invited somewhere or a toy or treat put down for her. Opening a piece
/// is heard from RoomSounds itself.
struct RoomChimeTriggers: ViewModifier {
    let placed: Int
    let invitation: UUID?
    let playing: Bool
    @Environment(\.roomChime) private var chime

    func body(content: Content) -> some View {
        content
            .onChange(of: placed) { chime(.confirm) }
            .onChange(of: invitation) { _, id in if id != nil { chime(.invite) } }
            .onChange(of: playing) { _, active in if active { chime(.invite) } }
    }
}

struct RoomSounds: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @AppStorage(RoomSoundKeys.music) private var music = false
    @AppStorage(RoomSoundKeys.effects) private var effects = true
    @AppStorage(RoomLightingMode.defaultsKey) private var lightingMode: RoomLightingMode = .constant
    /// The light phase of the saved light setting (not a draft being tried on in 房间装扮). Nil
    /// until the room's clock first reports, so a night launch starts on the night tune instead of
    /// cross-fading into it.
    @State private var lightPhase: RoomLightPhase?
    @State private var player = RoomAudioPlayer()

    private struct MusicKey: Equatable {
        let playing: Bool
        let track: RoomMusicTrack
    }

    private var musicKey: MusicKey {
        MusicKey(playing: music && phase == .active && lightPhase != nil,
                 track: .track(followsLocalTime: lightingMode == .localTime, phase: lightPhase ?? .daylight))
    }

    func body(content: Content) -> some View {
        let effectsOn = effects && phase == .active, player = player
        content
            .environment(\.roomChime, RoomChimeAction { if effectsOn { player.chime($0) } })
            // The room's own clock, for the saved setting: it wakes at each phase change and on
            // time zone or clock changes, and sleeps in the background.
            .background { LightPhaseReader { lightPhase = $0 }.roomLighting(mode: lightingMode) }
            .onChange(of: musicKey, initial: true) { _, key in
                player.setMusic(key.playing, track: key.track)
            }
            .onChange(of: effectsOn, initial: true) { _, enabled in
                if enabled { player.prepareChimes() } else { player.stopEffects() }
            }
            .onChange(of: model.bellaStatus) { _, status in
                if effectsOn, model.leadCat != nil { player.sound(for: status) }
            }
            .onChange(of: model.openedFurnitureID) { _, opened in
                if effectsOn, opened != nil { player.chime(.tap) }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                let info = notification.userInfo
                if info?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.ended.rawValue,
                   let raw = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                    player.setMusic(musicKey.playing, track: musicKey.track)
                }
            }
            .onDisappear { player.setMusic(false, track: musicKey.track); player.stopEffects() }
            #if DEBUG || DRILLS
            .overlay(alignment: .topLeading) {
                if RoomAudioPlayer.probeShown {
                    // `-MeowverseAudioProbe`: what the players are doing, for UI tests.
                    Text(verbatim: player.probe)
                        .font(.system(size: 2))
                        .opacity(0.02)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("room-audio-probe")
                }
            }
            #endif
    }
}

private struct LightPhaseReader: View {
    @Environment(\.roomLightPhase) private var phase
    let report: (RoomLightPhase) -> Void

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onChange(of: phase, initial: true) { _, phase in report(phase) }
    }
}

/// The room's players. Music: one looping player per tune, cross-faded on a phase change (see
/// `RoomMusicDeck`). Cat sounds: one at a time, the previous one faded out rather than cut.
/// Buttons: preloaded short PCM clips. All use the ambient session, so Silent Mode mutes them and
/// other apps' audio keeps playing, as before.
@MainActor @Observable
final class RoomAudioPlayer {
    static let musicVolume: Float = 0.28
    static let effectVolume: Float = 0.62
    /// The button clips are mastered about 9 dB under the cat sounds; same player volume.
    static let chimeVolume: Float = 0.62
    static let effectFadeOut: TimeInterval = 0.35
    #if DEBUG || DRILLS
    static let probeShown = ProcessInfo.processInfo.arguments.contains("-MeowverseAudioProbe")
    #endif

    /// For `-MeowverseAudioProbe` and the log: e.g. "music=room-music-night effect=purr#1 chime=ui-confirm#2".
    private(set) var probe = "music=off"

    @ObservationIgnored private var music: [RoomMusicTrack: AVAudioPlayer] = [:]
    @ObservationIgnored private var deck = RoomMusicDeck()
    @ObservationIgnored private var crossfade: Task<Void, Never>?
    @ObservationIgnored private var fadingTrack: RoomMusicTrack?
    @ObservationIgnored private var effect: (kind: RoomSoundEffect, player: AVAudioPlayer)?
    @ObservationIgnored private var fadingEffects: [AVAudioPlayer] = []
    @ObservationIgnored private var chimes: [RoomChime: AVAudioPlayer] = [:]
    @ObservationIgnored private var played: [String: Int] = [:]
    @ObservationIgnored private var crossfades = 0
    @ObservationIgnored private var lastEffect: String?
    @ObservationIgnored private var lastChime: String?
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "Meowverse", category: "room-audio")

    // MARK: Music

    func setMusic(_ playing: Bool, track: RoomMusicTrack) {
        for cue in deck.update(playing: playing, track: track) {
            switch cue {
            case .pause:
                cancelCrossfade()
                for player in music.values { player.pause() }
                log.notice("music pause")
            case .start(let track):
                cancelCrossfade()
                for (other, player) in music where other != track { player.pause() }
                guard let player = musicPlayer(track) else { break }
                player.volume = Self.musicVolume
                player.play()
                log.notice("music start \(track.rawValue, privacy: .public)")
            case .crossfade(let old, let new, let seconds):
                cancelCrossfade()
                guard let incoming = musicPlayer(new) else { break }
                // A tune still fading out (a quick change back) fades up from where it is.
                if !incoming.isPlaying {
                    incoming.volume = 0
                    incoming.currentTime = 0
                    incoming.play()
                }
                incoming.setVolume(Self.musicVolume, fadeDuration: seconds)
                let outgoing = music[old]
                outgoing?.setVolume(0, fadeDuration: seconds)
                fadingTrack = old
                crossfades += 1
                crossfade = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds + 0.1)) } catch { return }
                    outgoing?.pause()
                    self?.fadingTrack = nil
                    self?.updateProbe()
                }
                log.notice("music crossfade \(old.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public) \(seconds, privacy: .public)s")
            }
        }
        // After an interruption the system has paused the tune the deck still counts as playing.
        if let current = deck.current, let player = music[current], !player.isPlaying {
            player.volume = Self.musicVolume
            player.play()
        }
        updateProbe()
    }

    private func cancelCrossfade() {
        crossfade?.cancel()
        crossfade = nil
        fadingTrack = nil
    }

    private func musicPlayer(_ track: RoomMusicTrack) -> AVAudioPlayer? {
        if let player = music[track] { return player }
        let player = load(track.file)
        player?.numberOfLoops = -1
        music[track] = player
        return player
    }

    // MARK: Cat sounds

    func sound(for status: BellaStatus) {
        let action: CatAction? = switch status {
        case .onFloor(let current), .onFurniture(_, let current, _): current
        case .enjoying(let item): item.action
        default: nil
        }
        // Whatever she was doing is over: its sound fades instead of running on or being cut.
        fadeOutEffect()
        guard let kind = action.flatMap(RoomSoundEffect.effect(for:)), let player = load(kind.file) else {
            updateProbe()
            return
        }
        player.volume = Self.effectVolume
        player.play()
        effect = (kind, player)
        count(kind.rawValue)
        lastEffect = kind.rawValue
        log.notice("effect \(kind.rawValue, privacy: .public)")
        updateProbe()
    }

    private func fadeOutEffect() {
        guard let current = effect else { return }
        effect = nil
        guard current.player.isPlaying else { return }
        let player = current.player
        player.setVolume(0, fadeDuration: Self.effectFadeOut)
        fadingEffects.append(player)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.effectFadeOut + 0.05))
            player.stop()
            self?.fadingEffects.removeAll { $0 === player }
        }
    }

    func stopEffects() {
        effect?.player.stop()
        effect = nil
        for player in fadingEffects { player.stop() }
        fadingEffects = []
        for player in chimes.values { player.stop() }
        updateProbe()
    }

    // MARK: Buttons

    func prepareChimes() {
        for chime in RoomChime.allCases where chimes[chime] == nil {
            guard let player = load(chime.file) else { continue }
            player.volume = Self.chimeVolume
            player.prepareToPlay()
            chimes[chime] = player
        }
    }

    func chime(_ chime: RoomChime) {
        prepareChimes()
        guard let player = chimes[chime] else { return }
        player.currentTime = 0
        player.play()
        count(chime.rawValue)
        lastChime = chime.rawValue
        log.notice("chime \(chime.rawValue, privacy: .public)")
        updateProbe()
    }

    // MARK: Loading and the probe

    private func load(_ file: RoomSoundFile) -> AVAudioPlayer? {
        do {
            guard let url = Bundle.main.url(forResource: file.name, withExtension: file.ext) else {
                throw CocoaError(.fileNoSuchFile)
            }
            // Ambient audio respects Silent Mode and mixes with other apps.
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            return try AVAudioPlayer(contentsOf: url)
        } catch {
            missing.insert(file.name)
            log.error("Room sound unavailable: \(file.name, privacy: .public)")
            return nil
        }
    }

    private func count(_ name: String) { played[name, default: 0] += 1 }

    private func updateProbe() {
        let playing = deck.current.flatMap { music[$0]?.isPlaying == true ? $0.rawValue : nil } ?? "off"
        var parts = ["music=\(playing)", "crossfades=\(crossfades)"]
        if let fadingTrack { parts.append("fading=\(fadingTrack.rawValue)") }
        if let lastEffect { parts.append("effect=\(lastEffect)#\(played[lastEffect] ?? 0)") }
        if let lastChime { parts.append("chime=\(lastChime)#\(played[lastChime] ?? 0)") }
        if !missing.isEmpty { parts.append("missing=\(missing.sorted().joined(separator: ","))") }
        let next = parts.joined(separator: " ")
        if next != probe { probe = next }
    }
}

/// 音乐音效 from the room's top band, in a paper folio: the one place to switch the room's music
/// and action sounds.
struct RoomSoundPanel: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RoomSoundKeys.music) private var music = false
    @AppStorage(RoomSoundKeys.effects) private var effects = true

    var body: some View {
        RoomFolio(title: String(localized: "音乐音效"), image: "TopSound", illustration: "MemoryCompanion",
                  close: RoomFolioClose(label: Text("关闭"), id: "close-room-sound") { dismiss() }) {
            RoomFolioCard {
                RoomFolioToggleRow(title: Text("背景轻音乐"),
                                   note: Text("轻柔的钢琴曲。光线跟随当地时间时，夜里换一首更轻的。", tableName: "RoomSounds"),
                                   isOn: $music, id: "room-music")
                RoomFolioToggleRow(title: Text("猫咪动作音效"),
                                   note: Text("吃喝、玩耍、呼噜的小声音，和几下很轻的按键声。", tableName: "RoomSounds"),
                                   isOn: $effects, id: "room-sound-effects")
            }
        }
        // A container id: without `.contain` it would replace the ids of the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-sound-panel")
    }
}
