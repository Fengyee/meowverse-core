import Foundation
import Testing
@testable import MeowverseCore

struct RoomAudioTests {
    private static let phases: [RoomLightPhase] = [.dawn, .daylight, .dusk, .night]

    // MARK: Which tune

    @Test func steadyLightAlwaysPlaysTheDayTune() {
        for phase in Self.phases {
            #expect(RoomMusicTrack.track(followsLocalTime: false, phase: phase) == .day)
        }
    }

    @Test func localTimePlaysTheNightTuneOnlyInTheNightPhase() {
        #expect(RoomMusicTrack.track(followsLocalTime: true, phase: .night) == .night)
        for phase in [RoomLightPhase.dawn, .daylight, .dusk] {
            #expect(RoomMusicTrack.track(followsLocalTime: true, phase: phase) == .day, "\(phase)")
        }
    }

    @Test func theNightTuneStartsAtNineAndEndsAtSixLocalTime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let expected: [(String, RoomMusicTrack)] = [
            ("2026-11-16T20:59:59+08:00", .day), ("2026-11-16T21:00:00+08:00", .night),
            ("2026-11-17T05:59:59+08:00", .night), ("2026-11-17T06:00:00+08:00", .day)
        ]
        for (stamp, track) in expected {
            let phase = RoomLightPhase.local(at: try Date(stamp, strategy: .iso8601), in: cal)
            #expect(RoomMusicTrack.track(followsLocalTime: true, phase: phase) == track, "\(stamp)")
        }
    }

    // MARK: Switching tunes

    @Test func turningMusicOnStartsTheTuneAtOnceAndOffPausesIt() {
        var deck = RoomMusicDeck()
        #expect(deck.update(playing: true, track: .day) == [.start(.day)])
        #expect(deck.current == .day)
        #expect(deck.update(playing: true, track: .day) == [], "the same tune keeps playing")
        #expect(deck.update(playing: false, track: .day) == [.pause])
        #expect(deck.current == nil)
        #expect(deck.update(playing: false, track: .night) == [], "nothing to pause twice")
    }

    @Test func aNewPhaseCrossfadesBetweenTheTunesBriefly() {
        var deck = RoomMusicDeck()
        _ = deck.update(playing: true, track: .day)
        let cues = deck.update(playing: true, track: .night)
        #expect(cues == [.crossfade(from: .day, to: .night, seconds: RoomMusicDeck.crossfadeSeconds)])
        #expect(deck.current == .night)
        #expect(RoomMusicDeck.crossfadeSeconds >= 1 && RoomMusicDeck.crossfadeSeconds <= 3,
                "short, but long enough that neither tune is cut off")
        #expect(deck.update(playing: true, track: .day)
                == [.crossfade(from: .night, to: .day, seconds: RoomMusicDeck.crossfadeSeconds)])
    }

    @Test func aTuneChosenWhileSilentStartsWithoutACrossfade() {
        var deck = RoomMusicDeck()
        _ = deck.update(playing: true, track: .day)
        _ = deck.update(playing: false, track: .day)
        // The phase turned while the app was in the background or the music was off.
        #expect(deck.update(playing: true, track: .night) == [.start(.night)])
    }

    // MARK: Cat sounds

    @Test func eachActionHasItsSound() {
        let expected: [CatAction: RoomSoundEffect] = [.eat: .nibble, .drink: .lap, .play: .bat,
                                                     .loaf: .purr, .sleep: .purr]
        for action in CatAction.allCases {
            #expect(RoomSoundEffect.effect(for: action) == expected[action], "\(action)")
        }
    }

    // MARK: Files

    /// The app loads these by name from its Sounds folder: every cue must have its file there.
    @Test func everySoundHasItsRuntimeFile() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../Meowverse/Resources/Sounds").standardized
        let names = RoomMusicTrack.allCases.map(\.file) + RoomSoundEffect.allCases.map(\.file)
            + RoomChime.allCases.map(\.file)
        #expect(Set(names.map(\.name)).count == names.count, "no two sounds share a file")
        for file in names {
            let url = folder.appending(path: "\(file.name).\(file.ext)")
            let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, "\(url.lastPathComponent)")
            #expect(size > 1000, "\(url.lastPathComponent)")
        }
        #expect(RoomChime.allCases.allSatisfy { $0.file.ext == "caf" }, "button sounds start without decoding")
    }
}
