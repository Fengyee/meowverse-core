import Foundation
import Testing

/// The Live Activity's attributes (`ios/PocketCatShared/PocketCatAttributes.swift`, compiled in
/// here through the `PocketCatShared` symlinks): the cat's name added in round 11 is optional, so
/// a companion started by an older build still decodes after the update, and every name the app
/// can hold comes out as one short line or as no name at all.
@Suite struct PocketCatAttributesTests {
    /// Before round 11 the attributes were an empty struct. ActivityKit keeps the encoded bytes of
    /// a running activity across an app update; whichever coder it uses, an empty container must
    /// decode as "no name", not fail.
    @Test func aCompanionStartedBeforeNamesStillDecodes() throws {
        let fromJSON = try JSONDecoder().decode(PocketCatAttributes.self, from: Data("{}".utf8))
        #expect(fromJSON.catName == nil)
        #expect(fromJSON.shownName == nil)

        let emptyDictionary = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        let fromPlist = try PropertyListDecoder().decode(PocketCatAttributes.self, from: emptyDictionary)
        #expect(fromPlist.catName == nil)
    }

    /// The bytes the old empty struct actually wrote, with the old state beside them, as
    /// ActivityKit hands them back to the new extension.
    @Test func theOldAttributesBytesAndStateDecodeTogether() throws {
        struct OldAttributes: Codable {}
        let old = try JSONEncoder().encode(OldAttributes())
        let attributes = try JSONDecoder().decode(PocketCatAttributes.self, from: old)
        #expect(attributes.shownName == nil)

        let state = PocketCatState(startingWith: .watching, at: Date(timeIntervalSince1970: 1_800_000_000), interval: 300)
        let decoded = try JSONDecoder().decode(PocketCatState.self, from: try JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func aNameRoundTrips() throws {
        let attributes = PocketCatAttributes(catName: "Bella")
        let decoded = try JSONDecoder().decode(PocketCatAttributes.self, from: try JSONEncoder().encode(attributes))
        #expect(decoded.catName == "Bella")
        #expect(decoded.shownName == "Bella")
        let plist = try PropertyListDecoder().decode(PocketCatAttributes.self, from: try PropertyListEncoder().encode(attributes))
        #expect(plist.shownName == "Bella")
    }

    @Test(arguments: [
        ("Bella", "Bella"),
        ("  Bella \n", "Bella"),
        ("年糕", "年糕"),
        ("Bel\nla", "Bel la"),
        ("Bel\t\tla", "Bel la"),
        ("🍊小橘子", "🍊小橘子"),
    ])
    func namesAreOneTidyLine(raw: String, shown: String) {
        #expect(PocketCatAttributes(catName: raw).shownName == shown)
    }

    @Test(arguments: [nil, "", " ", "\n\t ", "\u{200B}"] as [String?])
    func noNameMeansNoName(raw: String?) {
        #expect(PocketCatAttributes(catName: raw).catName == nil)
        #expect(PocketCatAttributes(catName: raw).shownName == nil)
    }

    /// The app keeps names to 20 characters. Anything longer that still reaches the activity is
    /// cut on a character boundary, so an emoji is never split into a broken glyph.
    @Test func longNamesAreCutOnWholeCharacters() {
        let family = "👩‍👩‍👧‍👦"
        let long = String(repeating: family, count: 25)
        let shown = PocketCatAttributes(catName: long).shownName
        #expect(shown?.count == PocketCatAttributes.maxNameLength)
        #expect(shown == String(repeating: family, count: PocketCatAttributes.maxNameLength))
        #expect(PocketCatAttributes(catName: String(repeating: "长", count: 20)).shownName?.count == 20)
    }

    /// A decoded name gets the same cleaning, in case a future writer is less careful.
    @Test func aDecodedNameIsCleanedToo() throws {
        let raw = Data(#"{"catName":"  \n "}"#.utf8)
        #expect(try JSONDecoder().decode(PocketCatAttributes.self, from: raw).shownName == nil)
        let messy = Data(#"{"catName":" Mochi\n"}"#.utf8)
        #expect(try JSONDecoder().decode(PocketCatAttributes.self, from: messy).shownName == "Mochi")
    }

    /// ActivityKit allows 4 KB for attributes and state together.
    @Test func theLongestNameStaysWellUnderTheActivitySizeLimit() throws {
        let attributes = PocketCatAttributes(catName: String(repeating: "👩‍👩‍👧‍👦", count: 40))
        let state = PocketCatState(startingWith: .sleeping, at: .now, interval: PocketCatRotation.standardInterval)
        let size = try JSONEncoder().encode(attributes).count + JSONEncoder().encode(state).count
        #expect(size < 1024)
    }

    /// The control in Control Center starts a companion without the app's model, so the app
    /// leaves the name where the intent can read it.
    @Test func theRememberedNameIsWhatAControlStartsWith() throws {
        let suite = "PocketCatAttributesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PocketCatAttributes.remembered(in: defaults).shownName == nil)
        PocketCatAttributes.remember(" Bella ", in: defaults)
        #expect(PocketCatAttributes.remembered(in: defaults).shownName == "Bella")
        PocketCatAttributes.remember("", in: defaults)
        #expect(PocketCatAttributes.remembered(in: defaults).shownName == nil)
    }
}
