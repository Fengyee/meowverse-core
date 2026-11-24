import Foundation

/// What a companion keeps for its whole run. Foundation only: the Core tests compile this file
/// through a symlink (`MeowverseCore/Tests/MeowverseCoreTests/PocketCatShared/`), and the
/// ActivityKit conformance is added in `PocketCat.swift`.
///
/// The cat's name (round 11) is optional and decoded with `decodeIfPresent`: activities started
/// by an older build were encoded from an empty struct and must still decode after an update.
/// It is set when company begins and stays for that run; a rename shows from the next one.
nonisolated struct PocketCatAttributes: Codable, Hashable {
    typealias ContentState = PocketCatState

    /// The app keeps a cat's name to 20 characters; this is only a backstop.
    static let maxNameLength = 20

    /// Cleaned, or nil when there is no name to show.
    let catName: String?

    init(catName: String? = nil) {
        self.catName = Self.clean(catName)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catName = Self.clean(try container.decodeIfPresent(String.self, forKey: .catName))
    }

    /// The name as the Lock Screen and the watch show it: one line, nil when empty.
    var shownName: String? { Self.clean(catName) }

    /// One line of at most `maxNameLength` whole characters. Line breaks and runs of spaces
    /// become one space; invisible characters (zero-width spaces, stray controls) are dropped,
    /// while a joiner inside an emoji stays part of its character. nil if nothing is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var line = ""
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                pendingSpace = !line.isEmpty
                continue
            }
            if character.unicodeScalars.allSatisfy(isInvisible) { continue }
            if pendingSpace { line.append(" ") }
            pendingSpace = false
            line.append(character)
        }
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxNameLength))
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .control: true
        default: false
        }
    }

    // MARK: The name a control starts with

    /// A control in Control Center starts company without the app's model, so the app leaves
    /// the name it would use here: its own defaults, since the control's intent runs in the
    /// app's process. (The App Group holds only the running companion, no names.)
    private static let rememberedKey = "pocketCat.catName"

    static func remember(_ name: String?, in defaults: UserDefaults = .standard) {
        if let name = clean(name) { defaults.set(name, forKey: rememberedKey) } else { defaults.removeObject(forKey: rememberedKey) }
    }

    static func remembered(in defaults: UserDefaults = .standard) -> PocketCatAttributes {
        PocketCatAttributes(catName: defaults.string(forKey: rememberedKey))
    }
}
