import Foundation

/// A sound file in the app's Sounds folder (`Resources/Sounds/<name>.<ext>`).
public struct RoomSoundFile: Equatable, Sendable {
    public let name: String
    public let ext: String
}

/// The room's background music: a day tune and a quieter night tune, both endless loops.
public enum RoomMusicTrack: String, CaseIterable, Sendable {
    case day = "room-music"
    case night = "room-music-night"

    public var file: RoomSoundFile { RoomSoundFile(name: rawValue, ext: "m4a") }

    /// Follows the room's light setting: steady light keeps the day tune; light that follows the
    /// local time plays the night tune in the night phase (21:00–06:00) and the day tune otherwise.
    public static func track(followsLocalTime: Bool, phase: RoomLightPhase) -> Self {
        followsLocalTime && phase == .night ? .night : .day
    }
}

/// What the music player should do next.
public enum RoomMusicCue: Equatable, Sendable {
    /// Start or resume the tune at full volume.
    case start(RoomMusicTrack)
    /// Fade the old tune out while the new one fades in from its start.
    case crossfade(from: RoomMusicTrack, to: RoomMusicTrack, seconds: Double)
    /// Pause whatever plays, at once (backgrounded, music switched off, room closed).
    case pause
}

/// Which tune is audible, and the cues that get from there to what should be playing.
public struct RoomMusicDeck: Equatable, Sendable {
    /// Short, so a phase change is heard as a change, but long enough that neither tune is cut off.
    public static let crossfadeSeconds = 1.8

    public private(set) var current: RoomMusicTrack?

    public init() {}

    public mutating func update(playing: Bool, track: RoomMusicTrack) -> [RoomMusicCue] {
        guard playing else {
            defer { current = nil }
            return current == nil ? [] : [.pause]
        }
        defer { current = track }
        switch current {
        case nil: return [.start(track)]
        case track: return []
        case let old?: return [.crossfade(from: old, to: track, seconds: Self.crossfadeSeconds)]
        }
    }
}

/// The cat's sounds, played when she starts an action.
public enum RoomSoundEffect: String, CaseIterable, Sendable {
    case nibble, lap, bat, purr

    public var file: RoomSoundFile { RoomSoundFile(name: rawValue, ext: "m4a") }

    /// Eating, drinking and batting a toy; she purrs when she settles down to loaf or doze (on her
    /// own or when invited), the closest the room has to being close to her.
    public static func effect(for action: CatAction) -> Self? {
        switch action {
        case .eat: .nibble
        case .drink: .lap
        case .play: .bat
        case .loaf, .sleep: .purr
        case .sit, .scratch, .hide, .dig: nil
        }
    }
}

/// Very soft button sounds for the room's few main actions.
public enum RoomChime: String, CaseIterable, Sendable {
    /// Opening a piece of furniture from the room.
    case tap = "ui-tap-01"
    /// Inviting the cat somewhere or starting to play with her.
    case invite = "ui-tap-02"
    /// A piece placed in the room.
    case confirm = "ui-confirm"

    public var file: RoomSoundFile { RoomSoundFile(name: rawValue, ext: "caf") }
}
