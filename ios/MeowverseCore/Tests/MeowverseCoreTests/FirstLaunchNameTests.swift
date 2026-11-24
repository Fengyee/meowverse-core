import Foundation
import Testing
@testable import MeowverseCore

// Names typed at the first launch (the tour's naming page): how they are cleaned, and why they
// do not hide the iCloud restore offer (docs/onboarding/QA_T2.md F1, F2, F7).

struct FirstLaunchNameTests {
    @Test(arguments: [
        ("团子🐈‍⬛", "团子🐈‍⬛"),
        ("👩‍👩‍👧", "👩‍👩‍👧"),
        ("🏴󠁧󠁢󠁳󠁣󠁴󠁿", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"),
        ("❤️咪", "❤️咪"),
        ("Zoë", "Zoë"),
    ])
    func emojiAndJoinedLettersStayWhole(raw: String, kept: String) {
        #expect(AppState.normalizedCatName(raw) == kept)
        #expect(AppState.normalizedCatName(raw)?.unicodeScalars.count == kept.unicodeScalars.count)
        #expect(AppState.normalizedRoomName(raw) == kept)
    }

    @Test(arguments: [
        ("团\u{0007}子", "团子"),
        ("团\n子", "团子"),
        ("a\u{202E}b", "ab"),
        ("\u{200B}团子\u{200B}", "团子"),
        ("\u{FEFF}Kitty", "Kitty"),
    ])
    func controlAndInvisibleCharactersGo(raw: String, kept: String) {
        #expect(AppState.normalizedCatName(raw) == kept)
    }

    /// Joiners and tag characters with nothing visible to join are no name (QA_T2 R2-2).
    @Test(arguments: ["\u{200B}", " \u{0007} ", "", "\n", "\u{200D}", "\u{200D} ", " \u{200D} ",
                      "\u{200C}\u{200D}", "\u{E0041}\u{E0042}", "\u{200D}\u{E007F}"])
    func nothingVisibleIsNoName(raw: String) {
        #expect(AppState.normalizedCatName(raw) == nil)
        #expect(AppState.normalizedRoomName(raw) == nil)
    }

    /// A joiner left over at either end of a name joins nothing.
    @Test(arguments: [("a\u{200D}", "a"), ("\u{200C}团子", "团子"), ("团子\u{200D} ", "团子")])
    func strayJoinersAtTheEndsGo(raw: String, kept: String) {
        #expect(AppState.normalizedCatName(raw) == kept)
    }

    /// The restore offer reads only what a backup could bring back. A name given at the first
    /// launch keeps it; anything that restoring would lose takes it away.
    @Test func theRestoreOfferIgnoresNamesOnly() {
        var named = AppState.empty
        named.catName = "团子"
        named.cats = [Cat(catId: AppState.primaryCatId, name: "团子")]
        named.rooms = [Room(roomId: AppState.primaryRoomId, name: "小窝")]
        #expect(named.isEmptyForRestoreOffer)
        #expect(!named.isEmptyForBackup, "the backup itself still keeps the names")

        var catOnly = AppState.empty
        catOnly.catName = "团子"
        #expect(catOnly.isEmptyForRestoreOffer)

        #expect(AppState.empty.isEmptyForRestoreOffer)
    }

    @Test func aSecondCatARoomOrAPieceIsNotEmpty() {
        var twoCats = AppState.empty
        twoCats.cats = [Cat(catId: AppState.primaryCatId, name: "Kitty"), Cat(catId: "cat-2", name: "芝麻")]
        #expect(!twoCats.isEmptyForRestoreOffer)

        var twoRooms = AppState.empty
        twoRooms.rooms = [Room(roomId: AppState.primaryRoomId), Room(roomId: "room-2", name: "书房")]
        #expect(!twoRooms.isEmptyForRestoreOffer)

        var moved = AppState.empty
        moved.rooms = [Room(roomId: AppState.primaryRoomId), Room(roomId: "room-2")]
        moved.cats = [Cat(catId: AppState.primaryCatId, name: "Kitty", roomId: "room-2")]
        #expect(!moved.isEmptyForRestoreOffer)

        let piece = PhotoFurniture(instanceId: "chair", modelId: "kenney-chair", x: 0, z: 0, width: 1, depth: 1, turn: 0,
                                   finish: .original, displayName: "椅子", sources: [], tags: [], revision: 1)
        var stored = AppState.empty
        stored.storage = [piece]
        #expect(!stored.isEmptyForRestoreOffer)
        var placed = AppState.empty
        placed.items = [piece]
        #expect(!placed.isEmptyForRestoreOffer)
    }
}
